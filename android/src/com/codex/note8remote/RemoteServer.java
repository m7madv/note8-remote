package com.codex.note8remote;
import android.content.*;
import android.media.MediaMetadataRetriever;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.os.*;
import android.net.Uri;
import fi.iki.elonen.NanoHTTPD;
import fi.iki.elonen.NanoWSD;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;

final class RemoteServer extends NanoWSD implements RootClient.Listener {
    static final int PORT=8765,CHUNK=512*1024;
    final Context context;final String token;final RootClient root;
    volatile AudioClient audioClient;
    volatile VideoClient videoClient;
    final java.util.concurrent.atomic.AtomicInteger videoPending=new java.util.concurrent.atomic.AtomicInteger();
    final ExecutorService videoSender=Executors.newSingleThreadExecutor();
    final ThreadPoolExecutor audioSender=new ThreadPoolExecutor(1,1,0L,TimeUnit.MILLISECONDS,new ArrayBlockingQueue<Runnable>(4),new ThreadPoolExecutor.DiscardOldestPolicy());
    volatile Client client;volatile byte[] frame;volatile long frameAt;volatile JSONObject recordState=new JSONObject();
    final ExecutorService sender=Executors.newSingleThreadExecutor();
    final java.util.concurrent.atomic.AtomicBoolean sending=new java.util.concurrent.atomic.AtomicBoolean();
    volatile boolean recording=false,uploadBusy=false,viewing=true;
    volatile long lastRecordingWall=0;
    String uploadId;File upload;long expectedBytes;String expectedHash,kind;
    RemoteServer(Context context)throws Exception{
        super(PORT);
        setServerSocketFactory(()->new java.net.ServerSocket(){
            @Override public java.net.Socket accept() throws IOException {
                java.net.Socket socket=super.accept();socket.setTcpNoDelay(true);return socket;
            }
        });
        this.context=context;token=token(context);root=new RootClient(context,this);
    }
    static String token(Context context){SharedPreferences prefs=context.getSharedPreferences("remote",0);String value=prefs.getString("token",null);if(value==null){byte[] b=new byte[24];new SecureRandom().nextBytes(b);value=hex(b);prefs.edit().putString("token",value).commit();}return value;}
    static String hex(byte[] b){StringBuilder s=new StringBuilder();for(byte v:b)s.append(String.format(Locale.ROOT,"%02x",v&255));return s.toString();}
    static boolean privatePeer(String ip){
        if(ip==null)return false;if(ip.equals("127.0.0.1")||ip.equals("::1")||ip.equals("0:0:0:0:0:0:0:1")||ip.toLowerCase(Locale.ROOT).startsWith("fd7a:115c:a1e0:"))return true;
        String[] a=ip.split("\\.");try{return a.length==4&&Integer.parseInt(a[0])==100&&Integer.parseInt(a[1])>=64&&Integer.parseInt(a[1])<=127;}catch(Exception e){return false;}
    }
    static Response response(Response.Status status,JSONObject object){Response r=newFixedLengthResponse(status,"application/json; charset=utf-8",object.toString());r.addHeader("Cache-Control","no-store");r.addHeader("X-Content-Type-Options","nosniff");r.addHeader("Connection","close");return r;}
    static JSONObject object(String key,Object value){JSONObject o=new JSONObject();try{o.put(key,value);}catch(Exception ignored){}return o;}
    static Response fail(Response.Status status,String message){return response(status,object("error",message));}
    @Override public Response serve(IHTTPSession s){
        if(!privatePeer(s.getRemoteIpAddress()))return fail(Response.Status.FORBIDDEN,"الاتصال متاح عبر الشبكة الخاصة فقط.");
        String auth=s.getHeaders().get("authorization");
        if(auth==null||!MessageDigest.isEqual(("Bearer "+token).getBytes(StandardCharsets.UTF_8),auth.getBytes(StandardCharsets.UTF_8)))return fail(Response.Status.UNAUTHORIZED,"رمز الاقتران غير صحيح.");
        if(s.getHeaders().containsKey("origin"))return fail(Response.Status.FORBIDDEN,"استخدم تطبيق التحكم.");
        if(isWebsocketRequested(s)&&!s.getUri().equals("/stream")&&!s.getUri().equals("/audio")&&!s.getUri().equals("/audio-aac")&&!s.getUri().equals("/video"))return fail(Response.Status.NOT_FOUND,"مسار غير موجود.");
        return super.serve(s);
    }
    static long length(IHTTPSession s,int max)throws Exception{
        if(s.getHeaders().containsKey("transfer-encoding"))throw new IOException("Chunked body unsupported");
        long n=Long.parseLong(s.getHeaders().getOrDefault("content-length","0"));if(n<0||n>max)throw new IOException("حجم الطلب غير صالح.");return n;
    }
    static byte[] body(IHTTPSession s,int max)throws Exception{int n=(int)length(s,max);byte[] b=new byte[n];new DataInputStream(s.getInputStream()).readFully(b);return b;}
    static JSONObject bodyJSON(IHTTPSession s)throws Exception{return new JSONObject(new String(body(s,8192),StandardCharsets.UTF_8));}
    JSONObject status()throws Exception{
        JSONObject media=new JSONObject();boolean image=MediaFiles.imageMode();File source=image?MediaFiles.originalImage():MediaFiles.selected();
        media.put("kind",image?"image":"video").put("bytes",source.length()).put("active",MediaFiles.active());
        if(!image&&source.isFile()){
            MediaMetadataRetriever m=new MediaMetadataRetriever();try{m.setDataSource(source.getPath());media.put("durationMs",videoDuration(source)).put("width",Integer.parseInt(m.extractMetadata(18))).put("height",Integer.parseInt(m.extractMetadata(19)));}catch(Exception ignored){}finally{m.release();}
        }
        return new JSONObject().put("version","0.4").put("h264Screen",true).put("systemAudio",true).put("aacAudio",true).put("ready",root.ready).put("media",media).put("recording",recording).put("record",recordState).put("uploading",uploadBusy).put("screenAgeMs",frameAt==0?-1:SystemClock.elapsedRealtime()-frameAt);
    }
    static long videoDuration(File source)throws Exception{
        MediaExtractor extractor=new MediaExtractor();try{extractor.setDataSource(source.getPath());for(int i=0;i<extractor.getTrackCount();i++){MediaFormat f=extractor.getTrackFormat(i);if(f.getString(MediaFormat.KEY_MIME).startsWith("video/")&&f.containsKey(MediaFormat.KEY_DURATION))return f.getLong(MediaFormat.KEY_DURATION)/1000;}throw new IOException("مدة مسار الفيديو غير معروفة.");}finally{extractor.release();}
    }
    @Override protected Response serveHttp(IHTTPSession s){
        try{
            String path=s.getUri();Method method=s.getMethod();
            if(path.equals("/status")&&method==Method.GET)return response(Response.Status.OK,status());
            if(path.equals("/output")&&method==Method.GET){
                if(lastRecordingWall==0||recording)return fail(Response.Status.NOT_FOUND,"سجّل مقطعاً واحفظه إلى الاستوديو على النوت أولاً.");
                File[] files=new File("/storage/emulated/0/Snapchat").listFiles();File latest=null;
                if(files!=null)for(File f:files)if(f.isFile()&&f.getName().matches("Snapchat-[0-9]+\\.mp4")&&f.lastModified()>=lastRecordingWall&&f.length()>0&&(latest==null||f.lastModified()>latest.lastModified()))latest=f;
                if(latest==null)return fail(Response.Status.NOT_FOUND,"احفظ المقطع في الاستوديو على النوت ثم أعد المحاولة.");
                Response out=newFixedLengthResponse(Response.Status.OK,"video/mp4",new FileInputStream(latest),latest.length());out.addHeader("Cache-Control","no-store");return out;
            }
            if(path.equals("/frame")&&method==Method.GET){byte[] f=frame;if(f==null)return fail(Response.Status.SERVICE_UNAVAILABLE,"لم تصل الشاشة بعد.");Response r=newFixedLengthResponse(Response.Status.OK,"image/jpeg",new ByteArrayInputStream(f),f.length);r.addHeader("Cache-Control","no-store");return r;}
            if(path.equals("/upload")&&method==Method.GET){synchronized(this){return response(Response.Status.OK,new JSONObject().put("id",uploadId==null?"":uploadId).put("offset",upload==null?0:upload.length()));}}
            if(method!=Method.POST)return fail(Response.Status.NOT_FOUND,"مسار غير موجود.");
            if(path.equals("/upload/begin"))return begin(bodyJSON(s));
            if(path.equals("/upload/chunk"))return chunk(s);
            if(path.equals("/upload/finish"))return finish(bodyJSON(s));
            if(path.equals("/upload/pause")){bodyJSON(s);uploadBusy=false;setStream(client!=null);return response(Response.Status.OK,object("ok",true));}
            if(path.equals("/command")){JSONObject command=bodyJSON(s);command(command);return response(Response.Status.OK,object("ok",true));}
            return fail(Response.Status.NOT_FOUND,"مسار غير موجود.");
        }catch(Exception e){return fail(Response.Status.BAD_REQUEST,e.getMessage()==null?"تعذّر تنفيذ الطلب.":e.getMessage());}
    }
    synchronized Response begin(JSONObject c)throws Exception{
        if(recording)throw new IOException("انتظر انتهاء التسجيل.");
        long bytes=c.getLong("bytes");String sha=c.getString("sha256"),type=c.getString("kind");
        if(bytes<1||bytes>1024L*1024*1024||!sha.matches("[0-9a-f]{64}")||!(type.equals("image")||type.equals("video")))throw new IOException("بيانات الملف غير صالحة.");
        if(context.getCacheDir().getUsableSpace()<bytes*2+100*1024*1024)throw new IOException("المساحة المتاحة على النوت لا تكفي.");
        if(upload!=null&&expectedBytes==bytes&&sha.equals(expectedHash)&&type.equals(kind)){uploadBusy=true;setStream(client!=null);return response(Response.Status.OK,new JSONObject().put("id",uploadId).put("offset",upload.length()));}
        if(upload!=null)upload.delete();upload=new File(context.getCacheDir(),"incoming-media.part");if(upload.exists()&&!upload.delete())throw new IOException("تعذّر بدء النقل.");
        new FileOutputStream(upload).close();uploadId=UUID.randomUUID().toString();expectedBytes=bytes;expectedHash=sha;kind=type;uploadBusy=true;setStream(client!=null);
        return response(Response.Status.OK,new JSONObject().put("id",uploadId).put("offset",0));
    }
    synchronized Response chunk(IHTTPSession s)throws Exception{
        if(upload==null||!Objects.equals(uploadId,s.getParms().get("id")))throw new IOException("جلسة النقل غير موجودة.");
        long offset=Long.parseLong(s.getParms().getOrDefault("offset","-1"));if(offset!=upload.length())return response(Response.Status.CONFLICT,object("offset",upload.length()));
        long n=length(s,CHUNK);if(n<1||offset+n>expectedBytes)throw new IOException("حجم الجزء غير صالح.");
        // A partial network read never commits a partial chunk.
        byte[] bytes=body(s,CHUNK);try(FileOutputStream out=new FileOutputStream(upload,true)){out.write(bytes);out.getFD().sync();}
        return response(Response.Status.OK,object("offset",upload.length()));
    }
    synchronized Response finish(JSONObject c)throws Exception{
        if(recording)throw new IOException("انتظر انتهاء التسجيل.");
        if(upload==null||!Objects.equals(uploadId,c.optString("id"))||upload.length()!=expectedBytes)throw new IOException("لم يكتمل نقل الملف.");
        MessageDigest hash=MessageDigest.getInstance("SHA-256");try(InputStream in=new FileInputStream(upload)){byte[] b=new byte[128*1024];int n;while((n=in.read(b))!=-1)hash.update(b,0,n);}
        if(!expectedHash.equals(hex(hash.digest())))throw new IOException("بصمة الملف غير مطابقة. أعد النقل.");
        MediaFiles.importMedia(context.getContentResolver(),Uri.fromFile(upload),kind.equals("image"));
        String verified=expectedHash;upload.delete();upload=null;uploadId=null;uploadBusy=false;setStream(client!=null);
        return response(Response.Status.OK,status().put("sha256",verified));
    }
    void command(JSONObject c)throws Exception{
        if(!root.ready)throw new IOException("خدمة التحكم لم تبدأ بعد.");
        String type=c.getString("type");
        if(type.equals("view")){viewing=c.getBoolean("enabled");Client current=client;
            if(current!=null){current.ackFrames=c.optBoolean("frameAck");current.requestedFps=current.ackFrames?Math.max(8,Math.min(24,c.optInt("fps",24))):8;current.window.reset();}
            setStream(client!=null);return;}
        if(type.equals("frameAck")){Client current=client;if(current!=null)current.window.acknowledge(c.getLong("sequence"));return;}
        if(type.equals("record")){
            if(recording||uploadBusy)throw new IOException("انتظر انتهاء العملية الحالية.");
            JSONObject media=status().getJSONObject("media");long duration=media.optLong("durationMs",0);
            if(MediaFiles.imageMode()||!MediaFiles.active()||duration<500||duration>60000)throw new IOException("اختر فيديو مفعلاً مدته من 0.5 إلى 60 ثانية.");
            validatePoint(c);c.put("durationMs",duration).put("id",UUID.randomUUID().toString());recording=true;lastRecordingWall=System.currentTimeMillis();recordState=object("state","starting");
            try{root.send(c);}catch(Exception e){recording=false;throw e;}return;
        }
        if(type.equals("stopRecord")){root.send(c);return;}
        if(recording)throw new IOException("التحكم متوقف أثناء التسجيل التلقائي. يمكنك إيقاف التسجيل.");
        if(type.equals("touch")){validatePoint(c);int action=c.getInt("action");if(action!=0&&action!=1&&action!=2&&action!=3)throw new IOException("Invalid touch");root.send(c);}
        else if(type.equals("key")){int k=c.getInt("key");if(k!=3&&k!=4&&k!=187&&k!=224)throw new IOException("Invalid key");root.send(c);}
        else if(type.equals("text")){
            String text=c.getString("text");if(text.length()>2000)throw new IOException("النص طويل جداً.");
            new Handler(Looper.getMainLooper()).post(()->{((ClipboardManager)context.getSystemService(Context.CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("Remote",text));try{root.send(object("type","key").put("key",279));}catch(Exception ignored){}});
        }else if(type.equals("open")){
            String app=c.getString("app");if(!app.equals("com.snapchat.android")&&!app.equals("com.codex.note8camera"))throw new IOException("Invalid app");
            if(context.getPackageManager().getLaunchIntentForPackage(app)==null)throw new IOException("التطبيق غير مثبت.");
            // Root helper launches only these two fixed components, avoiding the
            // background app-switch delay after Home, without force-stopping.
            root.send(object("type","open").put("app",app));
        }else if(type.equals("active")){if(uploadBusy)throw new IOException("انتظر انتهاء النقل.");MediaFiles.setActive(c.getBoolean("enabled"));}
        else throw new IOException("أمر غير مدعوم.");
    }
    static void validatePoint(JSONObject c)throws Exception{double x=c.getDouble("x"),y=c.getDouble("y");if(!Double.isFinite(x)||!Double.isFinite(y)||x<0||x>1||y<0||y>1)throw new IOException("موضع اللمس غير صالح.");}
    void setStream(boolean enabled){setAudio();try{root.send(object("type","video").put("enabled",enabled&&viewing&&videoClient!=null).put("bitrate",uploadBusy?384000:1200000));root.send(object("type","stream").put("enabled",enabled&&viewing&&videoClient==null).put("width",480).put("fps",uploadBusy?1:(client==null?8:client.requestedFps)));}catch(Exception ignored){}}
    @Override public void frame(byte[] jpeg){frame=jpeg;frameAt=SystemClock.elapsedRealtime();Client c=client;if(c==null||!c.isOpen()||!sending.compareAndSet(false,true))return;
        sender.execute(()->{try{
            if(c!=client || !viewing)return;
            if(c.ackFrames){long sequence=c.window.reserve();if(sequence==0)return;
                java.nio.ByteBuffer packet=java.nio.ByteBuffer.allocate(12+jpeg.length);
                packet.putInt(0x4e384631).putLong(sequence).put(jpeg);c.send(packet.array());
            }else c.send(jpeg);
        }catch(Exception e){c.disconnect();}finally{sending.set(false);}});
    }
    @Override public void event(JSONObject e){String type=e.optString("type");if(type.equals("record")){recordState=e;recording=!e.optString("state").equals("finished");}else if(type.equals("error")){recording=false;recordState=e;}
        Client c=client;if(c!=null&&c.isOpen())sender.execute(()->{try{c.send(e.toString());}catch(Exception ignored){}});
    }
    void setAudio(){try{root.send(object("type","audio").put("enabled",client!=null&&viewing&&audioClient!=null).put("aac",audioClient!=null&&audioClient.aac));}catch(Exception ignored){}}
    @Override public void audio(byte[] pcm,boolean aac){
        AudioClient c=audioClient;if(c==null||!viewing||client==null||c.aac!=aac)return;
        audioSender.execute(()->{if(c!=audioClient||!viewing)return;try{c.send(pcm);}catch(Exception e){c.disconnect();}});
    }
    @Override protected WebSocket openWebSocket(IHTTPSession s){return s.getUri().equals("/stream")?new Client(s):s.getUri().equals("/video")?new VideoClient(s):new AudioClient(s);}
    @Override public void video(byte[] packet){
        VideoClient c=videoClient;if(c==null||client==null||!viewing)return;
        boolean key=packet.length>16&&(packet[7]&1)!=0;
        if(videoPending.get()>=6){if(!c.needsKey){c.needsKey=true;try{root.send(object("type","videoKey"));}catch(Exception ignored){}}return;}
        if(c.needsKey&&!key)return;
        long pts=java.nio.ByteBuffer.wrap(packet,8,8).getLong();
        if(c.ackRequired&&!c.window.reserve(pts)){if(!c.needsKey){c.needsKey=true;try{root.send(object("type","videoKey"));}catch(Exception ignored){}}return;}
        if(key)c.needsKey=false;
        videoPending.incrementAndGet();
        videoSender.execute(()->{try{if(c==videoClient&&viewing)c.send(packet);}catch(Exception e){c.disconnect();}finally{videoPending.decrementAndGet();}});
    }
    final class VideoClient extends WebSocket {
        volatile boolean needsKey=true;final boolean ackRequired;final VideoWindow window=new VideoWindow();
        VideoClient(IHTTPSession s){super(s);ackRequired="1".equals(s.getHeaders().get("x-note8-video-ack"));}
        @Override protected void onOpen(){VideoClient old=videoClient;videoClient=this;if(old!=null)old.disconnect();setStream(client!=null);try{root.send(object("type","videoKey"));}catch(Exception ignored){}}
        void disconnect(){try{close(WebSocketFrame.CloseCode.NormalClosure,"Disconnected",false);}catch(Exception ignored){}closed();}
        void closed(){if(videoClient==this){videoClient=null;setStream(client!=null);}}
        @Override protected void onClose(WebSocketFrame.CloseCode code,String reason,boolean remote){closed();}
        @Override protected void onMessage(WebSocketFrame f){String text=f.getTextPayload();if(text.startsWith("ack:")&&text.length()<32){try{window.acknowledge(Long.parseLong(text.substring(4)));}catch(Exception e){disconnect();}}else if("key".equals(text)){try{root.send(object("type","videoKey"));}catch(Exception ignored){}}else disconnect();}
        @Override protected void onPong(WebSocketFrame p){}
        @Override protected void onException(IOException e){closed();}
    }
    final class AudioClient extends WebSocket {
        final boolean aac;
        AudioClient(IHTTPSession s){super(s);aac=s.getUri().equals("/audio-aac");}
        @Override protected void onOpen(){AudioClient old=audioClient;audioClient=this;if(old!=null)old.disconnect();setAudio();}
        void disconnect(){try{close(WebSocketFrame.CloseCode.NormalClosure,"Disconnected",false);}catch(Exception ignored){}closed();}
        void closed(){if(audioClient==this){audioClient=null;audioSender.getQueue().clear();setAudio();}}
        @Override protected void onClose(WebSocketFrame.CloseCode code,String reason,boolean remote){closed();}
        @Override protected void onMessage(WebSocketFrame f){disconnect();}
        @Override protected void onPong(WebSocketFrame p){}
        @Override protected void onException(IOException e){closed();}
    }
    final class Client extends WebSocket{
        final FrameWindow window=new FrameWindow();volatile boolean ackFrames;volatile int requestedFps=8;
        Client(IHTTPSession s){super(s);}
        @Override protected void onOpen(){Client old=client;client=this;if(old!=null)old.disconnect();viewing=true;setStream(true);try{send(status().put("type","status").toString());}catch(Exception ignored){}}
        void disconnect(){try{close(WebSocketFrame.CloseCode.NormalClosure,"Disconnected",false);}catch(Exception ignored){}closed();}
        void closed(){if(client==this){client=null;VideoClient v=videoClient;if(v!=null)v.disconnect();AudioClient a=audioClient;if(a!=null)a.disconnect();setStream(false);try{root.send(object("type","cancelTouch"));}catch(Exception ignored){}}}
        @Override protected void onClose(WebSocketFrame.CloseCode c,String reason,boolean remote){closed();}
        @Override protected void onMessage(WebSocketFrame f){try{if(f.getTextPayload().length()>8192)throw new IOException("Request too large");JSONObject c=new JSONObject(f.getTextPayload());if(c.optString("type").equals("ping")){send(object("type","pong").toString());return;}command(c);}catch(Exception e){try{send(object("type","error").put("message",e.getMessage()).toString());}catch(Exception ignored){}}}
        @Override protected void onPong(WebSocketFrame p){}
        @Override protected void onException(IOException e){closed();}
    }
    @Override public void stop(){Client c=client;if(c!=null)c.disconnect();AudioClient a=audioClient;if(a!=null)a.disconnect();VideoClient v=videoClient;if(v!=null)v.disconnect();super.stop();root.close();sender.shutdownNow();audioSender.shutdownNow();videoSender.shutdownNow();}
}
