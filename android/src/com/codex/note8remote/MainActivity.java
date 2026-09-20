package com.codex.note8remote;
import android.Manifest;
import android.app.Activity;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Bundle;
import android.view.View;
import android.widget.*;
import java.net.*;
import java.util.*;
public final class MainActivity extends Activity{
 LinearLayout content; TextView status;
 int dp(int n){return Math.round(n*getResources().getDisplayMetrics().density);}
 TextView text(String s,int size){TextView t=new TextView(this);t.setText(s);t.setTextColor(Color.rgb(24,44,37));t.setTextSize(size);t.setPadding(0,dp(8),0,dp(8));content.addView(t);return t;}
 void button(String label,View.OnClickListener click){Button b=new Button(this);b.setText(label);b.setAllCaps(false);b.setMinHeight(dp(52));content.addView(b,new LinearLayout.LayoutParams(-1,-2));b.setOnClickListener(click);}
 static String address(){try{for(NetworkInterface n:Collections.list(NetworkInterface.getNetworkInterfaces()))for(InetAddress a:Collections.list(n.getInetAddresses()))if(a instanceof Inet4Address&&a.getHostAddress().startsWith("100.")&&RemoteServer.privatePeer(a.getHostAddress()))return a.getHostAddress();}catch(Exception ignored){}return "";}
 @Override public void onCreate(Bundle b){super.onCreate(b);ScrollView scroll=new ScrollView(this);content=new LinearLayout(this);content.setOrientation(1);content.setLayoutDirection(View.LAYOUT_DIRECTION_RTL);content.setPadding(dp(24),dp(28),dp(24),dp(24));content.setBackgroundColor(Color.rgb(244,247,246));scroll.addView(content);setContentView(scroll);
 text("التحكم بالنوت",30);text("اتصل من الآيفون، اختر المقطع، وتحكم بالشاشة.",17);status=text(RemoteService.running?"الخدمة تعمل":"الخدمة متوقفة",18);
 button("تشغيل خدمة التحكم",v->{if(checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)!=PackageManager.PERMISSION_GRANTED){requestPermissions(new String[]{Manifest.permission.READ_EXTERNAL_STORAGE,Manifest.permission.WRITE_EXTERNAL_STORAGE},8);return;}start();});
 button("إيقاف الخدمة",v->{getSharedPreferences("remote",0).edit().putBoolean("enabled",false).apply();stopService(new Intent(this,RemoteService.class));status.setText("الخدمة متوقفة");});
 text("ربط الآيفون",23);String ip=address();text(ip.isEmpty()?"شغّل Tailscale وسجّل الدخول إلى الشبكة نفسها على الهاتفين.":"عنوان النوت: "+ip,17);
 text("رمز الاقتران",15);TextView key=text(RemoteServer.token(this),16);key.setTextIsSelectable(true);key.setTextDirection(View.TEXT_DIRECTION_LTR);
 button("نسخ بيانات الربط",v->{String host=address();if(host.isEmpty()){Toast.makeText(this,"شغّل Tailscale أولاً.",0).show();return;}String link="note8remote://pair?host="+host+"&token="+RemoteServer.token(this);((ClipboardManager)getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(ClipData.newPlainText("Note8 Remote",link));Toast.makeText(this,"تم النسخ",0).show();});
 button("فتح Tailscale",v->{Intent i=getPackageManager().getLaunchIntentForPackage("com.tailscale.ipn");if(i!=null)startActivity(i);else Toast.makeText(this,"ثبّت Tailscale أولاً.",0).show();});
 text("الملفات تُنقل دون ضغط إضافي. جودة الشاشة أخف من الملف الأصلي. إيقاف التسجيل التلقائي يعتمد على مدة المقطع، ولا يرسل أي محتوى تلقائياً.",15);
 }
 void start(){getSharedPreferences("remote",0).edit().putBoolean("enabled",true).apply();startForegroundService(new Intent(this,RemoteService.class));status.setText("بدء الخدمة… وافق على إذن الروت إذا ظهر.");}
 @Override public void onRequestPermissionsResult(int r,String[] p,int[] g){super.onRequestPermissionsResult(r,p,g);if(r==8&&g.length>0&&g[0]==0)start();}
}
