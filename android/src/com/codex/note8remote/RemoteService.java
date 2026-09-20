package com.codex.note8remote;
import android.app.*;
import android.content.*;
import android.os.*;
public final class RemoteService extends Service{
    static volatile boolean running=false;RemoteServer server;PowerManager.WakeLock wake;
    @Override public void onCreate(){super.onCreate();NotificationManager nm=(NotificationManager)getSystemService(NOTIFICATION_SERVICE);nm.createNotificationChannel(new NotificationChannel("remote","التحكم بالنوت",NotificationManager.IMPORTANCE_LOW));
        Intent stop=new Intent(this,RemoteService.class).setAction("stop");PendingIntent action=PendingIntent.getService(this,1,stop,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
        Notification n=new Notification.Builder(this,"remote").setContentTitle("خدمة التحكم بالنوت تعمل").setContentText("الاتصال عبر الشبكة الخاصة ورمز الاقتران").setSmallIcon(android.R.drawable.ic_menu_view).setOngoing(true).addAction(new Notification.Action.Builder(null,"إيقاف",action).build()).build();startForeground(8,n);
        wake=((PowerManager)getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"note8remote:service");wake.acquire();
        try{server=new RemoteServer(this);server.start(30000,false);running=true;}catch(Exception e){android.util.Log.e("Note8Remote","Service start failed",e);stopSelf();}
    }
    @Override public int onStartCommand(Intent i,int flags,int id){if(i!=null&&"stop".equals(i.getAction())){getSharedPreferences("remote",0).edit().putBoolean("enabled",false).apply();stopSelf();return START_NOT_STICKY;}return START_STICKY;}
    @Override public void onDestroy(){running=false;if(server!=null)server.stop();if(wake!=null&&wake.isHeld())wake.release();super.onDestroy();}
    @Override public IBinder onBind(Intent i){return null;}
}
